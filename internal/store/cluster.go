package store

import (
	"database/sql"
	"errors"
	"strings"

	"github.com/vbskycn/flowmaster/internal/model"
)

// CreateClusterNode 新增受控服务器节点记录（仅存储 Token SHA-256 哈希与掩码）。
func (s *Store) CreateClusterNode(rec model.ClusterNodeRecord) error {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.db == nil {
		return errors.New("数据库已关闭")
	}
	_, err := s.db.Exec(`
		INSERT INTO cluster_nodes (
			id, name, group_name, remark, token_hash, token_mask, created_at, last_seen, last_ip, version, hostname, os, arch
		) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
		rec.ID, rec.Name, rec.GroupName, rec.Remark, rec.TokenHash, rec.TokenMask,
		rec.CreatedAt, rec.LastSeen, rec.LastIP, rec.Version, rec.Hostname, rec.OS, rec.Arch,
	)
	return err
}

// UpdateClusterNodeMeta 更新节点的展示名称、分组标签与备注。
func (s *Store) UpdateClusterNodeMeta(id, name, groupName, remark string) error {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.db == nil {
		return errors.New("数据库已关闭")
	}
	res, err := s.db.Exec(`
		UPDATE cluster_nodes SET name = ?, group_name = ?, remark = ? WHERE id = ?`,
		name, groupName, remark, id,
	)
	if err != nil {
		return err
	}
	affected, _ := res.RowsAffected()
	if affected == 0 {
		return errors.New("节点不存在")
	}
	return nil
}

// DeleteClusterNode 移除指定的集群节点注册记录。
func (s *Store) DeleteClusterNode(id string) error {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.db == nil {
		return errors.New("数据库已关闭")
	}
	_, err := s.db.Exec("DELETE FROM cluster_nodes WHERE id = ?", id)
	return err
}

// ListClusterNodes 返回所有已注册的被控节点记录。
func (s *Store) ListClusterNodes() ([]model.ClusterNodeRecord, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.db == nil {
		return nil, errors.New("数据库已关闭")
	}
	rows, err := s.db.Query(`
		SELECT id, name, group_name, remark, token_hash, token_mask, created_at, last_seen, last_ip, version, hostname, os, arch
		FROM cluster_nodes
		ORDER BY created_at ASC`)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	var list []model.ClusterNodeRecord
	for rows.Next() {
		var r model.ClusterNodeRecord
		if err := rows.Scan(
			&r.ID, &r.Name, &r.GroupName, &r.Remark, &r.TokenHash, &r.TokenMask,
			&r.CreatedAt, &r.LastSeen, &r.LastIP, &r.Version, &r.Hostname, &r.OS, &r.Arch,
		); err != nil {
			return nil, err
		}
		list = append(list, r)
	}
	return list, nil
}

// AuthenticateClusterNodeByHash 通过 Token SHA-256 哈希匹配合法节点。
func (s *Store) AuthenticateClusterNodeByHash(tokenHash string) (model.ClusterNodeRecord, bool, error) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.db == nil {
		return model.ClusterNodeRecord{}, false, errors.New("数据库已关闭")
	}
	var r model.ClusterNodeRecord
	err := s.db.QueryRow(`
		SELECT id, name, group_name, remark, token_hash, token_mask, created_at, last_seen, last_ip, version, hostname, os, arch
		FROM cluster_nodes WHERE token_hash = ?`, tokenHash,
	).Scan(
		&r.ID, &r.Name, &r.GroupName, &r.Remark, &r.TokenHash, &r.TokenMask,
		&r.CreatedAt, &r.LastSeen, &r.LastIP, &r.Version, &r.Hostname, &r.OS, &r.Arch,
	)
	if errors.Is(err, sql.ErrNoRows) {
		return model.ClusterNodeRecord{}, false, nil
	}
	if err != nil {
		return model.ClusterNodeRecord{}, false, err
	}
	return r, true, nil
}

// TouchClusterNodeHeartbeat 更新节点最近在线时间、来源 IP、系统环境及自动发现的节点名。
func (s *Store) TouchClusterNodeHeartbeat(id, currentName, reportedName, ip, version, hostname, osName, arch string, seenAt int64) error {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.db == nil {
		return errors.New("数据库已关闭")
	}
	newName := strings.TrimSpace(currentName)
	if newName == "" || strings.HasPrefix(newName, "待接入节点") {
		if strings.TrimSpace(reportedName) != "" {
			newName = strings.TrimSpace(reportedName)
		} else if strings.TrimSpace(hostname) != "" {
			newName = strings.TrimSpace(hostname)
		}
	}
	_, err := s.db.Exec(`
		UPDATE cluster_nodes
		SET name = ?, last_seen = ?, last_ip = ?, version = ?, hostname = ?, os = ?, arch = ?
		WHERE id = ?`,
		newName, seenAt, ip, version, hostname, osName, arch, id,
	)
	return err
}
